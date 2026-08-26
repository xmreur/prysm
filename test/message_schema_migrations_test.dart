// Targeted tests for MessageSchemaMigrations (Fase 4A step 3): the v2
// baseline schema, each v2->v10 upgrade step in isolation, the oldVersion=1
// full upgrade chain, the oversized-payload blob migration, and the
// chunked-read fallback helper.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/util/message_blob_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openBareDb() => databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );

List<String> _columnNames(List<Map<String, Object?>> pragmaRows) =>
    pragmaRows.map((c) => c['name'] as String).toList();

Future<bool> _tableExists(Database db, String name) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [name],
  );
  return rows.isNotEmpty;
}

Future<bool> _virtualTableExists(Database db, String name) async {
  return _tableExists(db, name);
}

void main() {
  late Directory docsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // migrateOversizedMessagePayloads shells out to path_provider via
    // MessageBlobStore.save.
    docsDir = Directory.systemTemp.createTempSync('message_schema_migrations_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
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
    docsDir.deleteSync(recursive: true);
  });

  group('onCreate (v2 baseline)', () {
    test('creates the messages table with the full v11 column set and satellite tables', () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);

      final columns = _columnNames(await db.rawQuery('PRAGMA table_info(messages)'));
      expect(columns, containsAll(<String>[
        'id', 'senderId', 'receiverId', 'message', 'type', 'fileName',
        'fileSize', 'timestamp', 'status', 'replyTo', 'readAt', 'viewOnce',
        'viewed', 'groupId', 'deletedAt', 'editedAt', 'forwarded',
      ]));

      expect(await _tableExists(db, 'message_reactions'), isTrue);
      expect(await _tableExists(db, 'message_read_receipts'), isTrue);
      expect(await _tableExists(db, 'self_messages'), isTrue);
      expect(await _tableExists(db, 'scheduled_messages'), isTrue);
      expect(await _virtualTableExists(db, 'message_search_fts'), isTrue);

      await db.close();
    });
  });

  group('upgrade steps (cascading onUpgrade contract)', () {
    // onUpgrade's dispatcher is a flat "if (oldVersion < N) run step N" chain
    // for every N in 2..10 — it always cascades to the latest version in one
    // call (newVersion is not used to bound it), matching how sqflite invokes
    // onUpgrade with the device's persisted oldVersion. There is no supported
    // way to invoke a single step in isolation, so these tests instead pin
    // down the version-gating boundary: for each starting oldVersion, every
    // "if (oldVersion < N)" branch below/at oldVersion is proven skipped and
    // every branch above it is proven to run.
    Future<Database> openV1BaselineDb() async {
      final db = await _openBareDb();
      await db.execute('''
        CREATE TABLE messages(
          id TEXT PRIMARY KEY,
          senderId TEXT NOT NULL,
          receiverId TEXT NOT NULL,
          message TEXT,
          type TEXT,
          fileName TEXT,
          fileSize INTEGER,
          timestamp INTEGER NOT NULL,
          status TEXT DEFAULT 'sent',
          replyTo TEXT
        )
      ''');
      return db;
    }

    /// Schema as it would look on a device already upgraded through v6:
    /// readAt/viewOnce/viewed/groupId present, but no deletedAt/editedAt and
    /// none of the v7/v9/v10 satellite tables yet.
    Future<Database> openV6StateDb() async {
      final db = await _openBareDb();
      await db.execute('''
        CREATE TABLE messages(
          id TEXT PRIMARY KEY,
          senderId TEXT NOT NULL,
          receiverId TEXT NOT NULL,
          message TEXT,
          type TEXT,
          fileName TEXT,
          fileSize INTEGER,
          timestamp INTEGER NOT NULL,
          status TEXT DEFAULT 'sent',
          replyTo TEXT,
          readAt INTEGER,
          viewOnce INTEGER DEFAULT 0,
          viewed INTEGER DEFAULT 0,
          groupId TEXT
        )
      ''');
      return db;
    }

    /// Schema as it would look on a device already upgraded through v8, plus
    /// the v7 reactions table it would already have — everything v9/v10
    /// introduce is deliberately absent so the gate boundary is observable.
    Future<Database> openV8StateDb() async {
      final db = await _openBareDb();
      await db.execute('''
        CREATE TABLE messages(
          id TEXT PRIMARY KEY,
          senderId TEXT NOT NULL,
          receiverId TEXT NOT NULL,
          message TEXT,
          type TEXT,
          fileName TEXT,
          fileSize INTEGER,
          timestamp INTEGER NOT NULL,
          status TEXT DEFAULT 'sent',
          replyTo TEXT,
          readAt INTEGER,
          viewOnce INTEGER DEFAULT 0,
          viewed INTEGER DEFAULT 0,
          groupId TEXT,
          deletedAt INTEGER,
          editedAt INTEGER
        )
      ''');
      await db.execute(
        'CREATE TABLE message_reactions(targetMessageId TEXT, reactorId TEXT, emoji TEXT, groupId TEXT, timestamp INTEGER)',
      );
      return db;
    }

    test('oldVersion=1 (pre-versioned device) runs the full v2..v10 chain, '
        'including id rescoping and the outbound readAt reset', () async {
      final db = await openV1BaselineDb();
      await db.execute('ALTER TABLE messages ADD COLUMN groupId TEXT');
      await db.insert('messages', {
        'id': 'wire1',
        'senderId': 'alice',
        'receiverId': 'alice',
        'groupId': 'g1',
        'status': 'sent',
        'timestamp': 1,
      });
      await db.insert('messages', {
        'id': 'sent1',
        'senderId': 'me',
        'receiverId': 'peer',
        'status': 'sent',
        'timestamp': 2,
      });

      await MessageSchemaMigrations.onUpgrade(db, 1, MessageSchemaMigrations.dbVersion);

      final columns = _columnNames(await db.rawQuery('PRAGMA table_info(messages)'));
      expect(columns, containsAll(<String>[
        'readAt', 'viewOnce', 'viewed', 'groupId', 'deletedAt', 'editedAt',
        'forwarded',
      ]));
      expect(await _tableExists(db, 'message_reactions'), isTrue);
      expect(await _tableExists(db, 'message_read_receipts'), isTrue);
      expect(await _tableExists(db, 'self_messages'), isTrue);
      expect(await _tableExists(db, 'scheduled_messages'), isTrue);

      final indexes = (await db.rawQuery('PRAGMA index_list(messages)'))
          .map((r) => r['name'])
          .toSet();
      expect(indexes, containsAll(<String>[
        'idx_read_status', 'idx_group_messages', 'idx_unread_inbound', 'idx_direct_peer_ts',
      ]));

      final scoped = (await db.query('messages', where: 'id = ?', whereArgs: ['g1::wire1']));
      expect(scoped, hasLength(1)); // v5 rescoped the unscoped group message id

      // v9's readAt reset applies to this row (status='sent' from the very
      // start, so column defaulted readAt to NULL — nothing to observe by
      // value, but the migration must not throw for rows without readAt set).
      final sent = (await db.query('messages', where: 'id = ?', whereArgs: ['sent1'])).single;
      expect(sent['readAt'], isNull);

      await db.close();
    });

    test('oldVersion=6 skips v2..v6 and only runs v7..v10, preserving already-applied state', () async {
      final db = await openV6StateDb();
      // Deliberately unscoped, mimicking a row v5 would have touched had it
      // run — it must NOT be touched now that v5 is gated out.
      await db.insert('messages', {
        'id': 'unscoped1',
        'senderId': 'alice',
        'receiverId': 'alice',
        'groupId': 'g1',
        'status': 'sent',
        'timestamp': 1,
      });
      await db.insert('messages', {
        'id': 'sent1',
        'senderId': 'me',
        'receiverId': 'peer',
        'status': 'sent',
        'readAt': 123,
        'timestamp': 2,
      });

      await MessageSchemaMigrations.onUpgrade(db, 6, MessageSchemaMigrations.dbVersion);

      final columns = _columnNames(await db.rawQuery('PRAGMA table_info(messages)'));
      expect(columns, containsAll(<String>['deletedAt', 'editedAt']));
      expect(await _tableExists(db, 'message_reactions'), isTrue);
      expect(await _tableExists(db, 'message_read_receipts'), isTrue);
      expect(await _tableExists(db, 'self_messages'), isTrue);

      // v5 (id rescoping) is gated out at oldVersion=6: the row keeps its
      // original unscoped id instead of being renamed to 'g1::unscoped1'.
      final untouched = await db.query('messages', where: 'id = ?', whereArgs: ['unscoped1']);
      expect(untouched, hasLength(1));

      // v9 (the sent-readAt reset) still runs since 6 < 9.
      final sent = (await db.query('messages', where: 'id = ?', whereArgs: ['sent1'])).single;
      expect(sent['readAt'], isNull);

      await db.close();
    });

    test('oldVersion=9 skips v2..v9 (including the readAt reset) and only runs v10', () async {
      final db = await openV8StateDb();
      await db.insert('messages', {
        'id': 'sent1',
        'senderId': 'me',
        'receiverId': 'peer',
        'status': 'sent',
        'readAt': 999,
        'timestamp': 1,
      });
      expect(await _tableExists(db, 'message_read_receipts'), isFalse);
      expect(await _tableExists(db, 'self_messages'), isFalse);

      await MessageSchemaMigrations.onUpgrade(db, 9, MessageSchemaMigrations.dbVersion);

      // v10 still runs since 9 < 10.
      expect(await _tableExists(db, 'self_messages'), isTrue);
      // v12 runs too, so an already-v9 install still gains scheduled sends.
      expect(await _tableExists(db, 'scheduled_messages'), isTrue);

      // v9 is gated out at oldVersion=9 (9 < 9 is false): neither the
      // read_receipts table nor the readAt reset happen on this call.
      expect(await _tableExists(db, 'message_read_receipts'), isFalse);
      final sent = (await db.query('messages', where: 'id = ?', whereArgs: ['sent1'])).single;
      expect(sent['readAt'], 999);

      await db.close();
    });
  });

  group('v14 FTS search index', () {
    test('onCreate includes message_search_fts virtual table', () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);

      expect(await _virtualTableExists(db, 'message_search_fts'), isTrue);

      await db.execute('''
        INSERT INTO message_search_fts(messageId, conversationId, scope, timestamp, body)
        VALUES ('m1', 'peer1', 'direct', 100, 'hello world')
      ''');
      final hits = await db.rawQuery(
        "SELECT messageId FROM message_search_fts WHERE message_search_fts MATCH 'hello'",
      );
      expect(hits, hasLength(1));
      expect(hits.first['messageId'], 'm1');

      await db.close();
    });

    test('upgrade from v13 adds message_search_fts', () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
      await db.execute('DROP TABLE IF EXISTS message_search_fts');
      expect(await _virtualTableExists(db, 'message_search_fts'), isFalse);

      await MessageSchemaMigrations.onUpgrade(db, 13, 14);

      expect(await _virtualTableExists(db, 'message_search_fts'), isTrue);
      await db.close();
    });
  });

  group('v15 FTS rowid side table', () {
    test('onCreate includes the rowid side table next to the FTS index',
        () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(
          db, MessageSchemaMigrations.dbVersion);

      expect(await _virtualTableExists(db, 'message_search_fts'), isTrue);
      expect(await _tableExists(db, 'message_search_rows'), isTrue);

      await db.close();
    });

    test('upgrade from v14 creates the side table and backfills it from the '
        'existing FTS index', () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(
          db, MessageSchemaMigrations.dbVersion);
      // Simulate a v14 install: the FTS index exists with data, the side
      // table does not.
      await db.execute('DROP TABLE IF EXISTS message_search_rows');
      await db.execute('''
        INSERT INTO message_search_fts(messageId, conversationId, scope, timestamp, body)
        VALUES ('m1', 'peer1', 'direct', 100, 'hello world'),
               ('m2', 'peer2', 'direct', 200, 'goodbye moon'),
               ('g1::m3', 'g1', 'group', 300, 'group note')
      ''');
      expect(await _tableExists(db, 'message_search_rows'), isFalse);

      await MessageSchemaMigrations.onUpgrade(
          db, 14, MessageSchemaMigrations.dbVersion);

      expect(await _tableExists(db, 'message_search_rows'), isTrue);
      final rows = await db.query('message_search_rows');
      expect(rows, hasLength(3));
      final byId = {
        for (final r in rows) r['messageId'] as String: r,
      };
      expect(byId['m1']!['timestamp'], 100);
      expect(byId['g1::m3']!['scope'], 'group');
      // The backfilled ftsRowid resolves to the same FTS row.
      final fts = await db.rawQuery(
        'SELECT messageId, rowid FROM message_search_fts WHERE messageId = ?',
        ['m1'],
      );
      expect(fts.single['rowid'], byId['m1']!['ftsRowid']);

      await db.close();
    });
  });

  group('v16 forwarded column', () {
    test('onCreate includes forwarded on messages and self_messages', () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(
        db,
        MessageSchemaMigrations.dbVersion,
      );

      final messageCols =
          _columnNames(await db.rawQuery('PRAGMA table_info(messages)'));
      expect(messageCols, contains('forwarded'));
      final selfCols =
          _columnNames(await db.rawQuery('PRAGMA table_info(self_messages)'));
      expect(selfCols, contains('forwarded'));

      await db.close();
    });

    test('upgrade from v15 adds forwarded to messages and self_messages',
        () async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(
        db,
        MessageSchemaMigrations.dbVersion,
      );
      await db.execute('ALTER TABLE messages DROP COLUMN forwarded');
      await db.execute('ALTER TABLE self_messages DROP COLUMN forwarded');
      expect(
        _columnNames(await db.rawQuery('PRAGMA table_info(messages)')),
        isNot(contains('forwarded')),
      );

      await MessageSchemaMigrations.onUpgrade(
        db,
        15,
        MessageSchemaMigrations.dbVersion,
      );

      expect(
        _columnNames(await db.rawQuery('PRAGMA table_info(messages)')),
        contains('forwarded'),
      );
      expect(
        _columnNames(await db.rawQuery('PRAGMA table_info(self_messages)')),
        contains('forwarded'),
      );

      await db.close();
    });
  });

  group('blob migration', () {
    Future<Database> openFullMessagesDb() async {
      final db = await _openBareDb();
      await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
      return db;
    }

    test('migrateOversizedMessagePayloads offloads large payloads and rewrites the row as a marker', () async {
      final db = await openFullMessagesDb();
      final bigPayload = 'y' * (MessageBlobStore.inlineThreshold + 100);
      await db.insert('messages', {
        'id': 'big1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': bigPayload,
        'timestamp': 1,
      });
      await db.insert('messages', {
        'id': 'small1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'tiny',
        'timestamp': 2,
      });

      await MessageSchemaMigrations.migrateOversizedMessagePayloads(db);

      final big = (await db.query('messages', where: 'id = ?', whereArgs: ['big1'])).single;
      expect(MessageBlobStore.isMarker(big['message'] as String?), isTrue);
      expect(await MessageBlobStore.read('big1'), bigPayload);

      final small = (await db.query('messages', where: 'id = ?', whereArgs: ['small1'])).single;
      expect(small['message'], 'tiny');

      await db.close();
    });

    test('migrateOversizedMessagePayloads leaves already-marked rows untouched', () async {
      final db = await openFullMessagesDb();
      await db.insert('messages', {
        'id': 'already1',
        'senderId': 'me',
        'receiverId': 'peer',
        'message': 'blob:already1',
        'timestamp': 1,
      });

      await MessageSchemaMigrations.migrateOversizedMessagePayloads(db);

      final row = (await db.query('messages', where: 'id = ?', whereArgs: ['already1'])).single;
      expect(row['message'], 'blob:already1');

      await db.close();
    });
  });

  group('readMessageColumnInChunks', () {
    test('reassembles a value split across chunk boundaries', () async {
      final db = await _openBareDb();
      await db.execute('CREATE TABLE messages(id TEXT PRIMARY KEY, message TEXT)');
      final payload = 'x' * 1200000; // spans multiple 500000-char chunks
      await db.insert('messages', {'id': 'm1', 'message': payload});

      final result = await MessageSchemaMigrations.readMessageColumnInChunks(db, 'm1');

      expect(result.length, payload.length);
      expect(result, payload);
      await db.close();
    });

    test('returns an empty string for a missing row', () async {
      final db = await _openBareDb();
      await db.execute('CREATE TABLE messages(id TEXT PRIMARY KEY, message TEXT)');

      final result = await MessageSchemaMigrations.readMessageColumnInChunks(db, 'missing');

      expect(result, '');
      await db.close();
    });
  });
}
