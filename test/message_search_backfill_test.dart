import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:prysm/services/message_search_backfill_service.dart';
import 'package:prysm/util/key_manager.dart';
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
}

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
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

  test('backfill skips rows that fail decrypt but marks complete', () async {
    final store = _FakeStore();
    final service = MessageSearchBackfillService(
      keyManager: KeyManager(),
      userId: 'me',
      store: store,
    );

    await service.startIfNeeded();

    expect(await store.isSearchBackfillComplete(), isTrue);
    const dao = MessageSearchDao();
    expect(await dao.searchGlobal('anything'), isEmpty);
  });
}
