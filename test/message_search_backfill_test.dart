import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/constants/group_constants.dart';
import 'package:prysm/crypto/key_store.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/models/unlock_type.dart';
import 'package:prysm/services/message_search_backfill_service.dart';
import 'package:prysm/util/key_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FailingSearchDao extends MessageSearchDao {
  const _FailingSearchDao();

  @override
  Future<void> upsert({
    required String messageId,
    required String conversationId,
    required String scope,
    required int timestamp,
    required String body,
  }) async {
    throw StateError('fts write failed');
  }
}

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
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    await db.insert('messages', {
      'id': 'm1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': 'encrypted',
      'type': 'text',
      'timestamp': 100,
      'status': 'sent',
    });
    MessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    await MessagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  Future<KeyManager> unlockedKeyManager() async {
    final keyManager = KeyManager();
    final ok = await keyManager.unlockWithPassphrase(
      'backfill-test-passphrase',
      type: UnlockType.passphrase,
    );
    expect(ok, isTrue);
    return keyManager;
  }

  test('backfill stops on decrypt failure, retains cursor, retries next run',
      () async {
    final store = _FakeStore();
    final service = MessageSearchBackfillService(
      keyManager: KeyManager(),
      userId: 'me',
      store: store,
    );

    await service.startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isFalse);
    expect(await store.getSearchBackfillPhase(), 'messages');
    expect(await store.getSearchBackfillCursorTimestamp(), 0);
    expect(await store.getSearchBackfillCursorId(), '');
    expect(await store.getSearchBackfillFailureCount('m1'), 1);
    const dao = MessageSearchDao();
    expect(await dao.searchGlobal('anything'), isEmpty);

    // A second startIfNeeded retries the same row without completing.
    await service.startIfNeeded();
    expect(await store.getSearchBackfillFailureCount('m1'), 2);
    expect(await store.isSearchBackfillComplete(), isFalse);
  });

  test('backfill indexes decryptable rows and marks complete', () async {
    final keyManager = await unlockedKeyManager();
    final encrypted = await keyManager.encryptForSelf('needle in haystack');
    final db = await MessagesDb.database;
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    await db.insert('messages', {
      'id': 'm1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': encrypted,
      'type': 'text',
      'timestamp': 100,
      'status': 'sent',
    });

    final store = _FakeStore();
    await MessageSearchBackfillService(
      keyManager: keyManager,
      userId: 'me',
      store: store,
    ).startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isTrue);
    expect(await store.getSearchBackfillPhase(), 'done');
    const dao = MessageSearchDao();
    final hits = await dao.searchGlobal('needle');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'm1');
  });

  test('messages-to-self transition resets the cursor to (0, \'\')', () async {
    final db = await MessagesDb.database;
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    await db.insert('self_messages', {
      'id': 's1',
      'message': 'encrypted',
      'type': 'text',
      'timestamp': 100,
    });

    final store = _FakeStore();
    await MessageSearchBackfillService(
      keyManager: KeyManager(),
      userId: 'me',
      store: store,
    ).startIfNeeded();

    expect(await store.getSearchBackfillPhase(), 'self');
    expect(await store.getSearchBackfillCursorTimestamp(), 0);
    expect(await store.getSearchBackfillCursorId(), '');
    expect(await store.isSearchBackfillComplete(), isFalse);
    expect(await store.getSearchBackfillFailureCount('s1'), 1);
  });

  test('resumption from a non-zero cursor skips earlier rows', () async {
    final keyManager = await unlockedKeyManager();
    final encrypted = await keyManager.encryptForSelf('needle in haystack');
    final db = await MessagesDb.database;
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    await db.insert('messages', {
      'id': 'm1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': encrypted,
      'type': 'text',
      'timestamp': 100,
      'status': 'sent',
    });
    await db.insert('messages', {
      'id': 'm2',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': encrypted,
      'type': 'text',
      'timestamp': 200,
      'status': 'sent',
    });

    final store = _FakeStore();
    await store.setSearchBackfillCursor(timestamp: 100, id: 'm1');
    await MessageSearchBackfillService(
      keyManager: keyManager,
      userId: 'me',
      store: store,
    ).startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isTrue);
    const dao = MessageSearchDao();
    final hits = await dao.searchGlobal('needle');
    // m1 sits at/behind the cursor and must not be re-indexed; only m2 is.
    expect(hits.map((h) => h.messageId).toList(), ['m2']);
  });

  test('resumption skips already-indexed rows', () async {
    final keyManager = await unlockedKeyManager();
    final encrypted = await keyManager.encryptForSelf('needle in haystack');
    final db = await MessagesDb.database;
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    await db.insert('messages', {
      'id': 'm1',
      'senderId': 'me',
      'receiverId': 'peer',
      'message': encrypted,
      'type': 'text',
      'timestamp': 100,
      'status': 'sent',
    });

    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer',
      scope: 'direct',
      timestamp: 100,
      body: 'pre-indexed copy',
    );

    final store = _FakeStore();
    await MessageSearchBackfillService(
      keyManager: keyManager,
      userId: 'me',
      store: store,
    ).startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isTrue);
    final hits = await dao.searchGlobal('pre-indexed');
    expect(hits, hasLength(1));
    expect(hits.first.body, 'pre-indexed copy');
  });

  test('backfill permanently skips a row after max retries and completes',
      () async {
    final store = _FakeStore();
    final service = MessageSearchBackfillService(
      keyManager: KeyManager(),
      userId: 'me',
      store: store,
    );

    // Exhaust the retry budget for m1, then a fresh run skips it permanently.
    for (var i = 0; i < 4; i++) {
      await service.startIfNeeded();
    }
    expect(await store.getSearchBackfillFailureCount('m1'), 4);
    expect(await store.isSearchBackfillComplete(), isFalse);

    await service.startIfNeeded();
    expect(await store.getSearchBackfillFailureCount('m1'), 5);
    expect(await store.isSearchBackfillComplete(), isTrue);
    const dao = MessageSearchDao();
    expect(await dao.searchGlobal('anything'), isEmpty);
  });

  test('identical wire ids in two groups are backfilled independently',
      () async {
    final db = await MessagesDb.database;
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    await db.insert('messages', {
      'id': 'groupA::shared',
      'senderId': 'alice',
      'receiverId': 'me',
      'message': 'unused',
      'type': groupFileType,
      'groupId': 'groupA',
      'fileName': 'alpha.txt',
      'timestamp': 100,
      'status': 'sent',
    });
    await db.insert('messages', {
      'id': 'groupB::shared',
      'senderId': 'alice',
      'receiverId': 'me',
      'message': 'unused',
      'type': groupFileType,
      'groupId': 'groupB',
      'fileName': 'beta.txt',
      'timestamp': 200,
      'status': 'sent',
    });

    final store = _FakeStore();
    await MessageSearchBackfillService(
      keyManager: KeyManager(),
      userId: 'me',
      store: store,
    ).startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isTrue);
    const dao = MessageSearchDao();
    final alpha = await dao.searchGlobal('alpha');
    expect(alpha, hasLength(1));
    expect(alpha.first.messageId, 'shared');
    expect(alpha.first.conversationId, 'groupA');
    final beta = await dao.searchGlobal('beta');
    expect(beta, hasLength(1));
    expect(beta.first.messageId, 'shared');
    expect(beta.first.conversationId, 'groupB');

    // Deleting one group's hit leaves the other group's hit intact.
    await dao.remove('shared', conversationId: 'groupA', scope: 'group');
    expect(await dao.searchGlobal('beta'), hasLength(1));
  });

  test('backfill retries when the FTS write fails, retaining the cursor',
      () async {
    final db = await MessagesDb.database;
    await db.delete('messages', where: 'id = ?', whereArgs: ['m1']);
    await db.insert('messages', {
      'id': 'groupX::m1',
      'senderId': 'alice',
      'receiverId': 'me',
      'message': 'unused',
      'type': groupFileType,
      'groupId': 'groupX',
      'fileName': 'f.txt',
      'timestamp': 100,
      'status': 'sent',
    });

    final store = _FakeStore();
    final service = MessageSearchBackfillService(
      keyManager: KeyManager(),
      userId: 'me',
      store: store,
      searchDao: const _FailingSearchDao(),
    );

    await service.startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isFalse);
    expect(await store.getSearchBackfillPhase(), 'messages');
    expect(await store.getSearchBackfillCursorTimestamp(), 0);
    expect(await store.getSearchBackfillCursorId(), '');
    expect(await store.getSearchBackfillFailureCount('groupX::m1'), 1);

    // A second run retries the same row instead of advancing past it.
    await service.startIfNeeded();
    expect(await store.getSearchBackfillFailureCount('groupX::m1'), 2);
    expect(await store.getSearchBackfillCursorTimestamp(), 0);
    expect(await store.isSearchBackfillComplete(), isFalse);

    const dao = MessageSearchDao();
    expect(await dao.searchGlobal('anything'), isEmpty);
  });
}
