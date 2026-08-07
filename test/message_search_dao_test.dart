import 'package:flutter_test/flutter_test.dart';
import 'package:prysm/database/message_schema_migrations.dart';
import 'package:prysm/database/message_search_dao.dart';
import 'package:prysm/database/messages.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await MessageSchemaMigrations.onCreate(db, MessageSchemaMigrations.dbVersion);
    MessagesDb.setDatabaseForTest(db);
  });

  tearDown(() async {
    await MessagesDb.close();
    MessagesDb.setDatabaseForTest(null);
  });

  test('escapeFtsQuery builds prefix OR query', () {
    expect(
      MessageSearchDao.escapeFtsQuery('hello world'),
      '"hello"* OR "world"*',
    );
    expect(MessageSearchDao.escapeFtsQuery('  '), '');
  });

  test('upsert search remove and global search', () async {
    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'hello world',
    );
    await dao.upsert(
      messageId: 'm2',
      conversationId: 'peer2',
      scope: 'direct',
      timestamp: 200,
      body: 'goodbye moon',
    );

    final hits = await dao.searchGlobal('hello');
    expect(hits, hasLength(1));
    expect(hits.first.messageId, 'm1');

    final scoped = await dao.searchInConversation('peer2', 'moon');
    expect(scoped, hasLength(1));
    expect(scoped.first.messageId, 'm2');

    await dao.remove('m1');
    expect(await dao.exists('m1'), isFalse);
    expect(await dao.searchGlobal('hello'), isEmpty);
  });

  test('upsert replaces existing row for same messageId', () async {
    const dao = MessageSearchDao();
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'first text',
    );
    await dao.upsert(
      messageId: 'm1',
      conversationId: 'peer1',
      scope: 'direct',
      timestamp: 100,
      body: 'edited text',
    );

    final hits = await dao.searchGlobal('edited');
    expect(hits, hasLength(1));
    expect(hits.first.body, 'edited text');
  });
}
