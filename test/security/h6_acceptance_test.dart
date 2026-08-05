// End-to-end acceptance test for the H6 at-rest-encryption fix.
//
// Every other test injects its database through the setDatabaseForTest seam,
// so none of them exercise the real openers. This file drives the real
// MessagesDatabase.database opener end to end against real SQLCipher files
// in a temp directory, with path_provider pointed at that directory and the
// database key held in memory (CryptoKeyStore.setUseInMemoryStorageOnly).
//
// The finding's own acceptance criterion, verbatim:
//   With Prysm closed, `sqlite3 <dataDir>/messages.db
//   "SELECT senderId FROM messages LIMIT 5;"` must fail with
//   "file is not a database".
//
// There is no sqlite3 CLI here (the assertion must hold on machines that do
// not have it): the criterion is expressed in Dart as (1) a raw unkeyed open
// of the file throwing when it reads sqlite_master, (2) the file not
// starting with the plaintext SQLite header, (3) the recognisable plaintext
// senderId values absent from the raw bytes of the file.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/database/messages_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The 16-byte header of a plaintext SQLite database: the ASCII bytes
/// `SQLite format 3` followed by a NUL. An encrypted SQLCipher file starts
/// with its random salt instead.
const List<int> _plaintextHeader = [
  0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite fo"
  0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00, // "rmat 3\0"
];

/// Recognisable plaintext values that must never survive at rest on disk.
const String _recognisableSenderId = 'h6-acceptance-sender-42';
const String _recognisableReceiverId = 'h6-acceptance-receiver-7';
const String _recognisablePayload = 'h6-acceptance-plaintext-payload';

/// True when [needle] appears as a contiguous byte run in [haystack].
bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

/// The database file plus any surviving WAL sidecar: every page ever written
/// to a keyed connection is encrypted, but scanning the sidecars too keeps
/// the assertion robust against checkpoint timing.
List<File> _dbFiles(String dbPath) => [
      File(dbPath),
      File('$dbPath-wal'),
      File('$dbPath-shm'),
    ].where((file) => file.existsSync()).toList();

/// Asserts the three at-rest properties of an encrypted database file:
/// no plaintext SQLite header, no recognisable senderId in the raw bytes
/// (including any surviving -wal sidecar), and an unkeyed raw open that
/// throws when it reads sqlite_master — the Dart expression of the
/// finding's "file is not a database" criterion.
Future<void> _expectEncryptedAtRest(String dbPath) async {
  final files = _dbFiles(dbPath);
  expect(files, isNotEmpty, reason: 'database file must exist at $dbPath');

  for (final file in files) {
    final bytes = file.readAsBytesSync();
    expect(
      bytes.length,
      greaterThanOrEqualTo(_plaintextHeader.length),
      reason: '${file.path} must be at least one SQLCipher page long',
    );
    expect(
      bytes.sublist(0, _plaintextHeader.length),
      isNot(_plaintextHeader),
      reason: '${file.path} must not start with the plaintext SQLite header '
          '("SQLite format 3"); an encrypted SQLCipher file starts with its '
          'random salt',
    );
    expect(
      _containsBytes(bytes, utf8.encode(_recognisableSenderId)),
      isFalse,
      reason: '${file.path} must not contain the recognisable senderId '
          '($_recognisableSenderId) in plaintext bytes',
    );
  }

  final unkeyed = await databaseFactory.openDatabase(
    dbPath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  addTearDown(unkeyed.close);
  await expectLater(
    unkeyed.rawQuery('SELECT count(*) FROM sqlite_master'),
    throwsA(isA<DatabaseException>()),
    reason: 'an unkeyed open of the encrypted database must fail on its '
        'first read: SQLCipher reports "file is not a database" '
        '(SQLITE_NOTADB) — the finding\'s acceptance criterion',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = Directory.systemTemp.createTempSync('h6_acceptance_test');
    dbPath = p.join(tempDir.path, 'prysm', 'messages.db');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return tempDir.path;
        }
        return null;
      },
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('h6_acceptance_test');
    dbPath = p.join(tempDir.path, 'prysm', 'messages.db');
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    CryptoKeyStore.resetInMemoryStorageForTest();
  });

  tearDown(() async {
    await MessagesDatabase.close();
    MessagesDatabase.setDatabaseForTest(null);
    CryptoKeyStore.resetInMemoryStorageForTest();
    CryptoKeyStore.setUseInMemoryStorageOnly(false);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  /// Builds a plaintext database with the app's real schema at [dbPath] —
  /// through [MessageSchemaMigrations.onCreate], the same code a
  /// pre-encryption install ran — with `user_version` set to the current
  /// schema version and two rows carrying recognisable senderId values.
  /// Closes it before returning.
  Future<void> buildPlaintextDatabase() async {
    final dir = Directory(p.dirname(dbPath));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final db = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: MessageSchemaMigrations.dbVersion,
        onCreate: MessageSchemaMigrations.onCreate,
        singleInstance: false,
      ),
    );
    try {
      await db.insert('messages', {
        'id': 'h6-upgrade-msg-1',
        'senderId': _recognisableSenderId,
        'receiverId': _recognisableReceiverId,
        'message': '$_recognisablePayload one',
        'type': 'text',
        'timestamp': 1700000001000,
        'status': 'sent',
      });
      await db.insert('messages', {
        'id': 'h6-upgrade-msg-2',
        'senderId': _recognisableSenderId,
        'receiverId': _recognisableReceiverId,
        'message': '$_recognisablePayload two',
        'type': 'text',
        'timestamp': 1700000002000,
        'status': 'sent',
      });
    } finally {
      await db.close();
    }
  }

  test(
    'upgrade path: a plaintext messages.db is migrated in place and '
    'encrypted end to end',
    () async {
      await buildPlaintextDatabase();

      // The fixture must really be plaintext before the open, or the
      // at-rest assertions below would be vacuous.
      final before = File(dbPath).readAsBytesSync();
      expect(
        before.sublist(0, _plaintextHeader.length),
        _plaintextHeader,
        reason: 'fixture must start out as a plaintext SQLite file',
      );
      expect(
        _containsBytes(before, utf8.encode(_recognisableSenderId)),
        isTrue,
        reason: 'fixture must carry the recognisable senderId in plaintext',
      );

      // The real opener: prepare() migrates the file, then openDatabase
      // keys the connection and reads the schema at user_version 13.
      final db = await MessagesDatabase.database;
      expect(
        db.path,
        dbPath,
        reason: 'the real opener must use the temp directory the test '
            'points path_provider at',
      );

      // Rows survive the migration and read back through the normal API.
      final rows = await MessagesDb.getMessagesBetween(
        _recognisableSenderId,
        _recognisableReceiverId,
      );
      expect(rows, hasLength(2));
      expect(
        rows.map((row) => row['senderId']).toSet(),
        {_recognisableSenderId},
      );
      expect(
        rows.map((row) => row['message']).toSet(),
        {'$_recognisablePayload one', '$_recognisablePayload two'},
      );
      final byId = await MessagesDb.getMessageById('h6-upgrade-msg-1');
      expect(byId, hasLength(1));
      expect(byId.first['senderId'], _recognisableSenderId);
      expect(byId.first['message'], '$_recognisablePayload one');

      await MessagesDatabase.close();

      await _expectEncryptedAtRest(dbPath);
    },
  );

  test(
    'fresh install: the real opener creates the database encrypted',
    () async {
      expect(
        File(dbPath).existsSync(),
        isFalse,
        reason: 'fresh install must start with no database file',
      );

      final db = await MessagesDatabase.database;
      expect(db.path, dbPath);

      await MessagesDb.insertMessage(
        {
          'id': 'h6-fresh-msg-1',
          'senderId': _recognisableSenderId,
          'receiverId': _recognisableReceiverId,
          'message': _recognisablePayload,
          'type': 'text',
          'timestamp': 1700000001000,
          'status': 'sent',
        },
        notifyListeners: false,
      );
      final found = await MessagesDb.getMessageById('h6-fresh-msg-1');
      expect(found, hasLength(1));
      expect(found.first['senderId'], _recognisableSenderId);
      expect(found.first['message'], _recognisablePayload);

      await MessagesDatabase.close();

      await _expectEncryptedAtRest(dbPath);
    },
  );
}
