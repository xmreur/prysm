import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/services/message_search_backfill_service.dart';
import 'package:prysm/services/message_search_index_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:prysm/util/message_blob_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeStore implements MessageSearchBackfillStore {
  final Map<String, Object> store = {};

  @override
  Future<bool> isSearchBackfillComplete() async =>
      store['search_backfill_complete'] as bool? ?? false;

  @override
  Future<void> setSearchBackfillComplete(bool value) async {
    store['search_backfill_complete'] = value;
  }

  @override
  Future<String> getSearchBackfillPhase() async =>
      store['search_backfill_phase'] as String? ?? 'messages';

  @override
  Future<void> setSearchBackfillPhase(String phase) async {
    store['search_backfill_phase'] = phase;
  }

  @override
  Future<int> getSearchBackfillCursorTimestamp() async =>
      store['search_backfill_cursor_ts'] as int? ?? 0;

  @override
  Future<String> getSearchBackfillCursorId() async =>
      store['search_backfill_cursor_id'] as String? ?? '';

  @override
  Future<void> setSearchBackfillCursor({
    required int timestamp,
    required String id,
  }) async {
    store['search_backfill_cursor_ts'] = timestamp;
    store['search_backfill_cursor_id'] = id;
  }

  @override
  Future<int> getSearchBackfillFailureCount(String rowKey) async =>
      store['search_backfill_failures_$rowKey'] as int? ?? 0;

  @override
  Future<void> setSearchBackfillFailureCount(String rowKey, int count) async {
    store['search_backfill_failures_$rowKey'] = count;
  }
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    CryptoKeyStore.setUseInMemoryStorageOnly(true);
    final docsDir = Directory.systemTemp.createTempSync('search_index_fixes');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    MessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    await MessagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  Future<KeyManager> unlockedKeyManager() async {
    final keyManager = KeyManager();
    final ok = await keyManager.unlockWithPassphrase(
      'search-index-fixes-passphrase',
      type: UnlockType.passphrase,
    );
    expect(ok, isTrue);
    return keyManager;
  }

  Future<Map<String, dynamic>> messageRow(String id) async {
    final db = await MessagesDb.database;
    return (await db.query('messages', where: 'id = ?', whereArgs: [id]))
        .single;
  }

  test('unviewed view-once rows are not indexed; normal rows are', () async {
    final db = await MessagesDb.database;
    await db.insert('messages', {
      'id': 'vo1',
      'senderId': 'alice',
      'receiverId': 'me',
      'message': 'unused',
      'type': 'file',
      'fileName': 'vo.png',
      'viewOnce': 1,
      'viewed': 0,
      'timestamp': 100,
      'status': 'received',
    });
    await db.insert('messages', {
      'id': 'n1',
      'senderId': 'alice',
      'receiverId': 'me',
      'message': 'unused',
      'type': 'file',
      'fileName': 'normal.txt',
      'timestamp': 200,
      'status': 'received',
    });

    final service =
        MessageSearchIndexService(keyManager: KeyManager(), userId: 'me');
    expect(await service.indexInboundRow(await messageRow('vo1'), 'me'),
        isTrue);
    expect(await service.indexInboundRow(await messageRow('n1'), 'me'),
        isTrue);

    const dao = MessageSearchDao();
    expect(await dao.searchGlobal('vo'), isEmpty);
    final hits = await dao.searchGlobal('normal');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'n1');
  });

  test('indexInboundRow resolves oversized blob markers before decrypting',
      () async {
    final keyManager = await unlockedKeyManager();
    final encrypted = await keyManager.encryptForSelf('needle in the haystack');
    final db = await MessagesDb.database;
    // A marker row is what prepareForStorage leaves behind for any payload
    // over MessageBlobStore.inlineThreshold.
    await db.insert('messages', {
      'id': 'big1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': MessageBlobStore.marker('big1'),
      'type': 'text',
      'timestamp': 100,
      'status': 'sent',
    });
    await MessageBlobStore.save('big1', encrypted);
    await db.insert('messages', {
      'id': 'small1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': await keyManager.encryptForSelf('second note mentions pineapple'),
      'type': 'text',
      'timestamp': 200,
      'status': 'sent',
    });

    final service = MessageSearchIndexService(
      keyManager: keyManager,
      userId: 'me',
    );
    expect(await service.indexInboundRow(await messageRow('big1'), 'me'),
        isTrue);
    expect(await service.indexInboundRow(await messageRow('small1'), 'me'),
        isTrue);

    const dao = MessageSearchDao();
    final bigHits = await dao.searchGlobal('needle');
    expect(bigHits, hasLength(1));
    expect(bigHits.first.messageId, 'big1');
    expect(bigHits.first.conversationId, 'peer');
    expect((await dao.searchGlobal('pineapple')), hasLength(1));
  });

  test('backfill completes over an oversized blob-marker row and resets '
      'its failure count', () async {
    final keyManager = await unlockedKeyManager();
    final encrypted = await keyManager.encryptForSelf('needle in the haystack');
    final db = await MessagesDb.database;
    await db.insert('messages', {
      'id': 'big1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': MessageBlobStore.marker('big1'),
      'type': 'text',
      'timestamp': 100,
      'status': 'sent',
    });
    await MessageBlobStore.save('big1', encrypted);
    await db.insert('messages', {
      'id': 'small1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': await keyManager.encryptForSelf('second note mentions pineapple'),
      'type': 'text',
      'timestamp': 200,
      'status': 'sent',
    });

    final store = _FakeStore();
    // Prior transient failures (e.g. before the group key existed) must not
    // burn the row once it indexes successfully.
    await store.setSearchBackfillFailureCount('big1', 3);

    await MessageSearchBackfillService(
      keyManager: keyManager,
      userId: 'me',
      store: store,
    ).startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isTrue);
    expect(await store.getSearchBackfillPhase(), 'done');
    expect(await store.getSearchBackfillFailureCount('big1'), 0);
    const dao = MessageSearchDao();
    final hits = await dao.searchGlobal('needle');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'big1');
    expect((await dao.searchGlobal('pineapple')), hasLength(1));
  });

  test('buildSnippet returns short bodies verbatim', () {
    // 37 chars, maxLen 80: the match window must not ellipsize a body that
    // already fits.
    const body = 'the pineapple upside down cake recipe';
    expect(MessageSearchIndexService.buildSnippet(body, 'recipe'), body);

    // Control: body exactly at maxLen is also returned unchanged.
    const atLimit = 'the second note mentions pineapple';
    expect(
      MessageSearchIndexService.buildSnippet(atLimit, 'note', maxLen: 34),
      atLimit,
    );
  });
}
